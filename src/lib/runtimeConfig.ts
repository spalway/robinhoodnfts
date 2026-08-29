// Deployment configuration, resolved at RUNTIME from Supabase rather than baked
// into the bundle at build time.
//
// WHY THIS EXISTS. The mint address, the wallet that receives payments, and the
// market links were VITE_ variables. Vite substitutes those during the build, so
// changing one meant a rebuild and a redeploy — and the mint address is the value
// most likely to need changing in a hurry, because it is the one that decides
// which token a visitor's wallet is asked to send. Config that takes a deploy to
// fix is config you cannot fix during an incident.
//
// They now live in one Supabase row. An operator edits it and every open browser
// picks it up on the next poll, with no deploy and no downtime.
//
// WHAT STAYED BUILD-TIME. The Supabase URL and anon key. They are what a browser
// needs to reach this table at all, so putting them in the table would be a
// circular dependency.
//
// THE SAFETY RULE IS UNCHANGED. Unset still means refuse. A config that has not
// loaded, failed to load, or carries an empty mint produces exactly the same
// answer as the old empty constant did: every real-value path declines and builds
// nothing. Making config dynamic must not make it optional.
import { fetchProtocolConfig, isSupabaseConfigured } from './supabase'

export interface RuntimeConfig {
  /** The $XCs SPL mint. Empty until the token is launched. */
  xnftMint: string
  /** Where a mint's 10,000 $XCs is sent. Empty means minting is disarmed. */
  devWallet: string
  /** Simulated marketplace fees only. */
  treasuryWallet: string
  /**
   * The Solana RPC this browser should use. Empty means fall back to the public
   * mainnet-beta endpoint.
   *
   * Unlike every other address here, an empty or wrong value is an AVAILABILITY
   * problem rather than a safety one — the endpoint decides how reliably a
   * transaction is read and confirmed, never where money goes. So this one
   * degrades instead of refusing: see resolveRpcEndpoint in spl.ts.
   */
  rpcUrl: string
  pumpFunUrl: string
  dexscreenerUrl: string
  supportHandle: string
  /** Lets an operator disarm minting without losing the address. */
  mintingEnabled: boolean
  /** False until a fetch has actually returned. Never assume loaded means valid. */
  loaded: boolean
  /** Where the current values came from, for the diagnostics an operator reads. */
  source: 'supabase' | 'unset' | 'error'
  /** Populated when source is 'error', so a page can say why rather than just refuse. */
  error: string | null
}

const EMPTY: RuntimeConfig = {
  xnftMint: '',
  devWallet: '',
  treasuryWallet: '',
  rpcUrl: '',
  pumpFunUrl: '',
  dexscreenerUrl: '',
  supportHandle: '',
  mintingEnabled: false,
  loaded: false,
  source: 'unset',
  error: null,
}

/**
 * The current snapshot.
 *
 * Module-level mutable state, which is normally worth avoiding — the reason it
 * is right here is that `spl.ts` composes transactions from synchronous pure
 * functions, and threading an async config through every one of them would put
 * a `Promise` in the middle of instruction building. A snapshot read at CALL
 * time (never at import time) keeps those functions synchronous while still
 * seeing the newest values.
 */
let current: RuntimeConfig = EMPTY

const listeners = new Set<() => void>()

/** Read the live config. Call this inside functions, never at module scope. */
export function getRuntimeConfig(): RuntimeConfig {
  return current
}

/**
 * True when a mint can be built: a token, a payee, and the operator's switch on.
 *
 * All three, because each failure mode is different and all three are bad. No
 * token means asking a wallet to send nothing. No payee means a transfer to
 * whatever an empty string parses into. Disabled means the operator deliberately
 * stopped it, and honouring that is the entire point of having the switch.
 */
export function isMintArmed(): boolean {
  return (
    current.loaded &&
    current.mintingEnabled &&
    current.xnftMint.length > 0 &&
    current.devWallet.length > 0
  )
}

function publish(next: RuntimeConfig) {
  current = next
  for (const fn of listeners) fn()
}

export function subscribeRuntimeConfig(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

/**
 * Fetch the config and publish it.
 *
 * Never throws and never rejects. A failure publishes a snapshot whose addresses
 * are empty — which disarms every real path — rather than leaving stale values in
 * place. That direction is deliberate: if an operator clears a compromised mint
 * address and a browser cannot reach Supabase, the safe outcome is that the
 * browser stops minting, not that it keeps using the address it remembers.
 */
export async function loadRuntimeConfig(): Promise<RuntimeConfig> {
  if (!isSupabaseConfigured()) {
    publish({ ...EMPTY, loaded: true, source: 'unset' })
    return current
  }

  const row = await fetchProtocolConfig()

  if (row === null) {
    publish({
      ...EMPTY,
      loaded: true,
      source: 'error',
      error: 'Could not read protocol config from Supabase. Minting is disarmed until it is readable.',
    })
    return current
  }

  publish({
    xnftMint: row.xnftMint,
    devWallet: row.devWallet,
    treasuryWallet: row.treasuryWallet,
    rpcUrl: row.rpcUrl,
    pumpFunUrl: row.pumpFunUrl,
    dexscreenerUrl: row.dexscreenerUrl,
    supportHandle: row.supportHandle,
    mintingEnabled: row.mintingEnabled,
    loaded: true,
    source: 'supabase',
    error: null,
  })
  return current
}

/** Test seam. Not exported through any barrel; production code never calls it. */
export function __setRuntimeConfigForTests(patch: Partial<RuntimeConfig>): void {
  publish({ ...current, ...patch })
}

export function __resetRuntimeConfigForTests(): void {
  publish({ ...EMPTY })
}
