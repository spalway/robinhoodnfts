// Server-side configuration.
//
// ===========================================================================
// THE CHAIN ADDRESSES COME FROM THE DATABASE, NOT FROM SECRETS
// ===========================================================================
// They used to be four Edge Function secrets. That arrangement had one failure
// mode and it already bit this project once, on the Solana launch: the browser
// reads the destination wallet from `protocol_config`, the verifier read it
// from a secret, the two were set at different times to different values, and
// every mint would have been rejected as `wrong-destination` — money moved,
// nothing issued, and the error blaming the buyer.
//
// Two sources of truth for one address is the bug. So there is one now, and it
// is the row the frontend already obeys. Setting the CA is a single UPDATE and
// the whole system arms at once; there is no second place to forget, and no way
// for the payer's destination and the verifier's expectation to disagree.
//
// This is safe because `protocol_config` is not writable by anyone who could
// abuse it: RLS is on, three restrictive policies deny writes, and neither anon
// nor authenticated holds UPDATE or INSERT. Only service_role — whose key never
// leaves this server — and an operator at the dashboard can change it.
//
// CHAIN_RPC_URL survives as an OPTIONAL secret, and only as an override: an
// operator swapping to a paid endpoint under load should not have to touch the
// same row the mint destination lives in.
//
// The remaining env reads are the three Supabase credentials, which the
// platform injects on its own. Nothing here requires manual setup.
import { isAddress } from './evm.ts'
import { fnError, isFnError, type FnError } from './http.ts'

/** Robinhood Chain's public mainnet RPC. Verified to answer eth_chainId 0x1237. */
const FALLBACK_RPC = 'https://rpc.mainnet.chain.robinhood.com'

export interface FunctionConfig {
  /** Robinhood Chain JSON-RPC endpoint (chain id 4663). */
  rpcUrl: string
  /** 0x contract of the $XCs ERC-20. The only token these functions will index. */
  xnftMint: string
  /** The operator's treasury. Defaults to the dev wallet when unset. */
  treasury: string
  /** Where a mint's payment must land. Read from config, never from a request body. */
  devWallet: string
  /** False when treasury and dev wallet are the same address — a supported shape. */
  sweepsFees: boolean
  /** Injected by the platform — the Edge Function's own project. */
  supabaseUrl: string
  /** Injected by the platform. Bypasses RLS; never leaves the server. */
  serviceRoleKey: string
  /** Injected by the platform. Public by design; grants nothing on its own. */
  anonKey: string
}

export type PlatformConfig = Pick<FunctionConfig, 'supabaseUrl' | 'serviceRoleKey' | 'anonKey'>

export function loadPlatformConfig(): PlatformConfig | FnError {
  const supabaseUrl = read('SUPABASE_URL')
  const serviceRoleKey = read('SUPABASE_SERVICE_ROLE_KEY')
  const anonKey = read('SUPABASE_ANON_KEY')
  if (!supabaseUrl || !serviceRoleKey || !anonKey) {
    return fnError('not-configured', 'The function is missing its Supabase platform credentials.')
  }
  return { supabaseUrl, serviceRoleKey, anonKey }
}

function read(name: string): string {
  return (Deno.env.get(name) ?? '').trim()
}

interface ConfigRow {
  xnft_mint: string | null
  dev_wallet: string | null
  treasury_wallet: string | null
  rpc_url: string | null
}

/**
 * The one config row, read with the service key.
 *
 * Deliberately not cached. An operator who pastes the CA expects the next mint
 * to work, not the one after some TTL expires — and this runs once per
 * verification, which is a rate measured in mints per minute.
 */
async function readConfigRow(platform: PlatformConfig): Promise<ConfigRow | FnError> {
  let response: Response
  try {
    response = await fetch(
      `${platform.supabaseUrl}/rest/v1/protocol_config?select=xnft_mint,dev_wallet,treasury_wallet,rpc_url&id=eq.1`,
      {
        headers: {
          apikey: platform.serviceRoleKey,
          Authorization: `Bearer ${platform.serviceRoleKey}`,
        },
      },
    )
  } catch (e) {
    const detail = e instanceof Error ? e.message : 'unknown error'
    return fnError('database', 'Could not reach the database to read protocol_config.', detail)
  }
  if (!response.ok) {
    return fnError('database', 'The database refused a read of protocol_config.')
  }
  let rows: ConfigRow[]
  try {
    rows = (await response.json()) as ConfigRow[]
  } catch {
    return fnError('database', 'protocol_config returned an unreadable response.')
  }
  if (!Array.isArray(rows) || rows.length === 0) {
    return fnError('not-configured', 'protocol_config has no row 1. Nothing was read.')
  }
  return rows[0]
}

/**
 * An address from the config row, or the reason it is unusable.
 *
 * Empty means "not launched yet" and is the honest default. A value that is not
 * a 0x address is refused rather than compared — a base58 Solana address pasted
 * into a Robinhood Chain deployment would otherwise fail every comparison in the
 * verifier and look like fraud rather than a typo.
 */
function requireAddress(value: string | null, field: string, purpose: string): string | FnError {
  const trimmed = (value ?? '').trim()
  if (!trimmed) {
    return fnError(
      'not-configured',
      `protocol_config.${field} is not set, so ${purpose}. Nothing was read and nothing was written.`,
    )
  }
  if (!isAddress(trimmed)) {
    return fnError('not-configured', `protocol_config.${field} is not a 0x EVM address.`)
  }
  return trimmed
}

/**
 * The whole config, or the first reason it is unusable. Async now, because the
 * chain addresses live in Postgres — callers check once at the top of a handler.
 */
export async function loadConfig(): Promise<FunctionConfig | FnError> {
  const platform = loadPlatformConfig()
  if (isFnError(platform)) return platform

  const row = await readConfigRow(platform)
  if (isFnError(row)) return row

  const xnftMint = requireAddress(row.xnft_mint, 'xnft_mint', 'no transfer can be attributed to $XCs')
  if (typeof xnftMint !== 'string') return xnftMint

  const devWallet = requireAddress(row.dev_wallet, 'dev_wallet', 'no mint destination can be verified')
  if (typeof devWallet !== 'string') return devWallet

  // Optional. It gates nothing confirm-mint does, and demanding it would block a
  // launch on a value that changes no outcome — exactly the kind of over-broad
  // gate that teaches operators to paste placeholders.
  const rawTreasury = (row.treasury_wallet ?? '').trim()
  const treasury = rawTreasury && isAddress(rawTreasury) ? rawTreasury : devWallet

  // Secret first (an operator's paid endpoint), then the config row, then the
  // public RPC. Every layer is a real endpoint, so there is no "unset" state
  // that could stall a verification.
  const override = read('CHAIN_RPC_URL')
  const fromRow = (row.rpc_url ?? '').trim()
  const rpcUrl = override || fromRow || FALLBACK_RPC
  if (!/^https?:\/\//i.test(rpcUrl)) {
    return fnError('not-configured', 'The configured RPC URL is not an http(s) endpoint.')
  }

  return { rpcUrl, xnftMint, treasury, devWallet, sweepsFees: treasury !== devWallet, ...platform }
}
