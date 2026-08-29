// Every real transfer of $XCs this app can make, composed as raw ERC-20 calls
// against Robinhood Chain.
//
// This replaces src/lib/spl.ts, which did the same job with SPL Token
// instructions on Solana. The shape of the problem barely changed — one
// transfer, one destination, one exact amount — but almost every mechanism did:
//
//   Solana                        Robinhood Chain
//   -------------------------     ----------------------------------------
//   base58 addresses              0x-prefixed 20-byte hex, case-insensitive
//   associated token accounts     none; a balance is a mapping on the token
//   transferChecked instruction   `transfer(address,uint256)` calldata
//   signature (base58, 64B)       transaction hash (0x, 32B)
//   balance deltas per account    a Transfer event log
//
// NO DEPENDENCY. viem or ethers would be the ordinary choice, and both were
// considered — but the entire ERC-20 surface this app touches is three function
// selectors and one event topic, all of them fixed constants. Hand-encoding two
// 32-byte words is smaller and more auditable than pulling an ABI coder into a
// bundle to do it, and it keeps this file the same kind of thing spl.ts was:
// something you can read end to end and check.
//
// The rules are carried over unchanged from spl.ts, because none of them were
// about Solana:
//
//   1. Nothing throws. Every async path resolves to an EvmError the UI renders.
//   2. Configuration is a gate. Addresses default to empty and every path
//      refuses while what it needs is unset.
//   3. Destinations are never caller-supplied. The project wallet comes from
//      runtime config; a transfer helper that took a destination would be an
//      arbitrary-transfer primitive with a friendlier name.
//   4. Building and sending are separate calls.
//   5. Money is bigint. The only float is a display `uiAmount`, and it never
//      decides an amount.
import { getRuntimeConfig, isMintArmed } from './runtimeConfig'
import { MINT_BURN } from './fees'

// ---------------------------------------------------------------------------
// The chain
// ---------------------------------------------------------------------------

/**
 * Robinhood Chain mainnet. Verified live: eth_chainId returns 0x1237.
 *
 * Gas is paid in ETH — the chain has no native token of its own, which is worth
 * knowing before a buyer wonders why they need ETH to spend $XCs.
 */
export const CHAIN_ID = 4663
export const CHAIN_ID_HEX = '0x1237'
export const CHAIN_NAME = 'Robinhood Chain'

/**
 * Last resort only. The public endpoint is free and rate-limited; a deployment
 * sets `rpc_url` in protocol_config and this is never reached.
 */
export const DEFAULT_RPC = 'https://rpc.mainnet.chain.robinhood.com'

const EXPLORER = 'https://robinhoodchain.blockscout.com'

export function explorerTx(hash: string): string {
  return `${EXPLORER}/tx/${hash}`
}

function cfg() {
  return getRuntimeConfig()
}

/** The $XCs ERC-20, as configured right now. Never cached — see runtimeConfig. */
export function tokenAddress(): string {
  return cfg().xnftMint
}

/** Where a mint's proceeds go. Read from config, never from a parameter. */
export function projectWallet(): string {
  return cfg().devWallet
}

export function rpcEndpoint(endpoint?: string): string {
  const candidate = endpoint ?? cfg().rpcUrl
  if (!candidate) return DEFAULT_RPC
  try {
    const { protocol } = new URL(candidate)
    return protocol === 'http:' || protocol === 'https:' ? candidate : DEFAULT_RPC
  } catch {
    return DEFAULT_RPC
  }
}

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/

export function isAddress(value: string): boolean {
  return ADDRESS_RE.test(value.trim())
}

/**
 * Lower-cased for comparison, and that matters more here than it looks.
 *
 * EVM addresses are case-insensitive, but EIP-55 checksums them with mixed
 * case — so the same wallet arrives as `0xAbC…` from a wallet, `0xabc…` from a
 * log, and `0xABC…` from a hand-typed config row. Comparing raw strings would
 * make the verifier reject a perfectly good payment because a letter was
 * capitalised.
 */
export function normalise(value: string): string {
  return value.trim().toLowerCase()
}

export function sameAddress(a: string | null, b: string | null): boolean {
  if (!a || !b) return false
  return normalise(a) === normalise(b)
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

export type EvmErrorCode =
  | 'not-configured'
  | 'no-wallet'
  | 'wrong-chain'
  | 'insufficient-balance'
  | 'rejected'
  | 'network'
  | 'unknown'

export interface EvmError {
  code: EvmErrorCode
  message: string
  /** Whole tokens still needed, when the failure is about balance. */
  shortfall?: number
}

const CODES: ReadonlySet<string> = new Set([
  'not-configured',
  'no-wallet',
  'wrong-chain',
  'insufficient-balance',
  'rejected',
  'network',
  'unknown',
])

export function isEvmError(v: unknown): v is EvmError {
  if (typeof v !== 'object' || v === null) return false
  const c = v as { code?: unknown; message?: unknown }
  return typeof c.code === 'string' && CODES.has(c.code) && typeof c.message === 'string'
}

function fail(code: EvmErrorCode, message: string, shortfall?: number): EvmError {
  return shortfall === undefined ? { code, message } : { code, message, shortfall }
}

const NOT_CONFIGURED =
  'The $XCs token address is not set, so nothing can be built or sent. Nothing was read.'

export function isMintConfigured(): boolean {
  return isMintArmed() && isAddress(tokenAddress()) && isAddress(projectWallet())
}

// ---------------------------------------------------------------------------
// ABI encoding, by hand
// ---------------------------------------------------------------------------
//
// Three selectors and nothing else. Each is the first four bytes of the keccak
// hash of its signature — fixed, public constants, written out rather than
// derived so this file needs no hashing at runtime.

/** `balanceOf(address)` */
const SEL_BALANCE_OF = '0x70a08231'
/** `decimals()` */
const SEL_DECIMALS = '0x313ce567'
/** `transfer(address,uint256)` */
const SEL_TRANSFER = '0xa9059cbb'

/** Left-pad to one 32-byte ABI word. */
function word(hexNoPrefix: string): string {
  return hexNoPrefix.replace(/^0x/, '').toLowerCase().padStart(64, '0')
}

function encodeAddress(address: string): string {
  return word(normalise(address).slice(2))
}

function encodeUint(value: bigint): string {
  return word(value.toString(16))
}

// ---------------------------------------------------------------------------
// JSON-RPC
// ---------------------------------------------------------------------------

interface RpcOk<T> {
  ok: true
  value: T
}

async function rpc<T>(method: string, params: unknown[], endpoint?: string): Promise<RpcOk<T> | EvmError> {
  let response: Response
  try {
    response = await fetch(rpcEndpoint(endpoint), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    })
  } catch (e) {
    const detail = e instanceof Error ? e.message : 'unknown error'
    return fail('network', `Could not reach ${CHAIN_NAME}: ${detail}`)
  }

  if (!response.ok) return fail('network', `${CHAIN_NAME} refused the request (${response.status}).`)

  let body: { result?: unknown; error?: { message?: string } }
  try {
    body = (await response.json()) as typeof body
  } catch {
    return fail('network', `${CHAIN_NAME} returned an unreadable response.`)
  }

  if (body.error) return fail('network', body.error.message ?? 'The node reported an error.')
  return { ok: true, value: body.result as T }
}

/** A read-only contract call. */
async function call(to: string, data: string, endpoint?: string): Promise<string | EvmError> {
  const result = await rpc<string>('eth_call', [{ to: normalise(to), data }, 'latest'], endpoint)
  if (isEvmError(result)) return result
  return typeof result.value === 'string' ? result.value : fail('network', 'The node returned no call result.')
}

function hexToBigInt(hex: string): bigint | null {
  if (typeof hex !== 'string' || !/^0x[0-9a-fA-F]*$/.test(hex)) return null
  return hex === '0x' ? 0n : BigInt(hex)
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

export interface TokenBalance {
  uiAmount: number
  decimals: number
  rawAmount: bigint
  /**
   * Always true on EVM, and kept only so the UI's shape matches what it had.
   * On Solana this said whether an associated token account existed at all;
   * here a balance is a mapping entry and reading it always succeeds, so a
   * wallet that has never held $XCs reads zero rather than "no account".
   */
  exists: boolean
}

/** Exact within a float's range: whole and fractional parts convert separately. */
function toUiAmount(raw: bigint, decimals: number): number {
  const base = 10n ** BigInt(decimals)
  return Number(raw / base) + Number(raw % base) / Number(base)
}

export async function fetchDecimals(endpoint?: string): Promise<number | EvmError> {
  const token = tokenAddress()
  if (!isAddress(token)) return fail('not-configured', NOT_CONFIGURED)

  const raw = await call(token, SEL_DECIMALS, endpoint)
  if (isEvmError(raw)) return raw
  const value = hexToBigInt(raw)
  // A token claiming an implausible precision is not one this app can price.
  if (value === null || value < 0n || value > 36n) {
    return fail('not-configured', '$XCs reports an implausible decimal count.')
  }
  return Number(value)
}

export async function fetchTokenBalance(
  owner: string,
  endpoint?: string,
): Promise<TokenBalance | EvmError> {
  if (!isMintConfigured()) return fail('not-configured', NOT_CONFIGURED)
  if (!isAddress(owner)) return fail('no-wallet', 'Connect a wallet to read your $XCs balance.')

  const decimals = await fetchDecimals(endpoint)
  if (isEvmError(decimals)) return decimals

  const raw = await call(tokenAddress(), SEL_BALANCE_OF + encodeAddress(owner), endpoint)
  if (isEvmError(raw)) return raw
  const amount = hexToBigInt(raw)
  if (amount === null) return fail('network', 'The node returned an unreadable balance.')

  return { uiAmount: toUiAmount(amount, decimals), decimals, rawAmount: amount, exists: true }
}

// ---------------------------------------------------------------------------
// The mint
// ---------------------------------------------------------------------------

/** Whole $XCs a mint costs, and — since there is no fee — the entire debit. */
export const MINT_COST = Number(MINT_BURN)

export interface MintRequest {
  /** EIP-1193 transaction, ready for eth_sendTransaction. */
  from: string
  to: string
  data: string
  /** No ETH moves; the value is the token transfer in `data`. */
  value: '0x0'
}

/**
 * The unsigned transfer: 10,000 $XCs from the buyer to the project wallet.
 *
 * Checks the balance first, so an underfunded wallet gets a sentence rather
 * than a signature prompt it should never have seen. Signs nothing.
 */
export async function buildMintRequest(
  owner: string,
  endpoint?: string,
): Promise<MintRequest | EvmError> {
  if (!isMintConfigured()) return fail('not-configured', NOT_CONFIGURED)
  if (!isAddress(owner)) return fail('no-wallet', 'Connect a wallet to hire an xployee.')

  const balance = await fetchTokenBalance(owner, endpoint)
  if (isEvmError(balance)) return balance

  const needed = MINT_BURN * 10n ** BigInt(balance.decimals)
  if (balance.rawAmount < needed) {
    const short = toUiAmount(needed - balance.rawAmount, balance.decimals)
    return fail(
      'insufficient-balance',
      `You need ${MINT_COST.toLocaleString('en-US')} $XCs to hire an xployee. Short ${short.toLocaleString('en-US', { maximumFractionDigits: 4 })} $XCs.`,
      short,
    )
  }

  return {
    from: normalise(owner),
    to: normalise(tokenAddress()),
    data: SEL_TRANSFER + encodeAddress(projectWallet()) + encodeUint(needed),
    value: '0x0',
  }
}

/**
 * Signs and sends. Call from a click handler and nowhere else — it is the point
 * of no return.
 *
 * Signing is delegated to the wallet's own method, so no key material passes
 * through this module. Unlike the Solana version there is no confirmation poll
 * here: the hash comes back immediately and the backend verifier decides
 * whether it landed, which is the one place that decision belongs.
 */
export async function sendMint(
  owner: string,
  signAndSend: (request: MintRequest) => Promise<string>,
  endpoint?: string,
): Promise<{ hash: string } | EvmError> {
  const request = await buildMintRequest(owner, endpoint)
  if (isEvmError(request)) return request

  try {
    const hash = await signAndSend(request)
    if (typeof hash !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(hash)) {
      return fail('unknown', 'The wallet returned no usable transaction hash.')
    }
    return { hash }
  } catch (e) {
    return classifySendError(e)
  }
}

/**
 * A user declining must never be reported as a failure worth retrying
 * automatically, and must never look like a payment that might have landed.
 * EIP-1193 gives 4001 for a rejection; wallets also say it in prose.
 */
export function classifySendError(e: unknown): EvmError {
  const code = (e as { code?: unknown })?.code
  const message = e instanceof Error ? e.message : String(e ?? '')
  if (code === 4001 || /reject|denied|cancel/i.test(message)) {
    return fail('rejected', 'You declined the transaction. Nothing was sent.')
  }
  if (code === 4902 || /unrecognized chain|wrong network/i.test(message)) {
    return fail('wrong-chain', `Switch your wallet to ${CHAIN_NAME} and try again.`)
  }
  if (/insufficient funds/i.test(message)) {
    // ETH for gas, not $XCs — the token balance was checked before building.
    return fail('insufficient-balance', `You need a little ETH on ${CHAIN_NAME} to pay gas.`)
  }
  return fail('unknown', message || 'The wallet could not send the transaction.')
}
